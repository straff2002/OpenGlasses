# Plan CO — Privacy Filter, Identity Ambiguity, Thinking Budget & Turn-Taking

**Status:** ✅ Items 0–4 built (2026-08-08), full suite green (2834 tests, 0 failures). Device smoke
owed — see P3.
**Method:** fork-network delta sweep, 2026-08-08 — same methodology as CD and CJ: take the *defect
class* from field reports elsewhere, then verify against our own code before believing it applies.
Two of the four items below reproduce here, one is a real defect of a different shape than reported,
and one is a latent risk we're structurally exposed to. Nothing is adopted on the strength of the
report alone.
**Shape:** four independent pure cores (P1), their wiring (P2), device smoke (P3). One PR.

---

## Item 0 — The privacy filter was never called (found while unblocking CN)

Not from the sweep. Found while answering Plan CN's blocking question — *are camera frames pre- or
post-`PrivacyFilterService`?* — and the answer turned out to be neither.

`processFrame` and `filteredPublisher` had **no call sites anywhere in the app**. The service was
constructed, its `isEnabled` tracked the setting, it suspended and resumed on lifecycle — and no
frame was ever passed to it. The "Blur Bystander Faces" toggle in Settings did nothing, on any path,
while its copy promised protection "during streaming or recording". CLAUDE.md listed the feature as
Tier 2 DONE. That is a false promise to the user about other people's privacy, so it shipped first.

**Where it now applies.** A new `PrivacyFilterScope` answers "which consumers?" in one tested place,
because two constraints pull in opposite directions:

- **Face recognition must see raw pixels.** The blur is indiscriminate (the known-contact exemption
  was removed in BK P6 as dead code), so filtering ahead of recognition would blur the very faces
  the user enrolled and break the feature outright.
- **Blurring costs a Vision pass plus a Core Image composite per frame.** Affordable on the
  model-facing paths, which `FrameThrottler` has already cut to roughly 1 fps. Not affordable at
  recording or broadcast frame rates without an off-main pipeline that does not exist.

So v1 covers egress to third-party models — `liveSession`, `directModelTurn`, `pinnedFrame`, and
CN's `agentAttachment` — which is both the highest-stakes path and the cheap one. Recording,
broadcast and expert streams are **not covered**, and the Settings copy now says so outright rather
than implying the opposite. Applied at the chokepoints, the same shape `FramePin` uses and for the
same reason: filtering inside `CameraService` would catch consumers that must not be filtered.

A pin is filtered **once, at pin time**, so every downstream use — sharp-inject, heartbeat resends,
Direct-mode reuse, the on-screen pinned card, a CN attachment — carries the same blurred pixels
without repeating the Vision pass.

`filteredPublisher` was deleted rather than left in place: no callers (the same disease), and it
sampled `isEnabled` once at construction so a mid-session toggle would never have reached it. Same
judgement as the BK P6 removal in that file — don't ship a surface that doesn't do what its name says.

**Tests** (`PrivacyFilterScopeTests`): every model-facing consumer filtered; face recognition
exempt; recording/broadcast asserted *not* covered, so the day someone builds the 30 fps pipeline
this test fails and reminds them to update the Settings copy; `allCases` walked so a new consumer
must classify itself.

**Still open:** the recording and broadcast paths. They need a dedicated off-main blur pipeline, and
that is a plan of its own, not a rider here.

---

## Item 1 — A confident wrong name (verified gap)

`FaceMatcher.bestMatch(for:among:threshold:)` returns `Int?` — the single highest-scoring candidate
that strictly exceeds the threshold, with **no notion of a runner-up**. It cannot express doubt, and
`FaceRecognitionService:265` is its only caller.

So two enrolled people with close faceprints — siblings, a parent and child, anyone the embedding
finds similar — resolve to whichever scores a hair higher, and the wearer hears a confident greeting
by the wrong name with nothing anywhere in the path having noticed the call was close. A wrong name
said out loud to someone's face is among the more socially expensive failures this app can produce,
and it is currently indistinguishable from a correct one.

The margin between top-1 and top-2 is the information we're throwing away. Where the two are close,
the honest output is a question, not an assertion.

**Core.** `FaceMatcher.match(for:among:threshold:margin:) -> MatchOutcome`:

```
.confident(index, similarity)          // clears threshold, and beats runner-up by >= margin
.ambiguous([(index, similarity)])      // clears threshold, runner-up within margin — 2+ candidates
.none                                  // nothing clears the threshold
```

`bestMatch` stays, reimplemented over `match` so existing callers and tests are untouched.
`.confident` is the only outcome that may produce a name.

**Wiring.** The announce path speaks the ambiguity ("that might be Sam or Alex") instead of picking.
The recognition tool returns the candidate list rather than a single name, so the model can ask.
Default `margin` starts conservative; it is a `Config` value because the right number is empirical
and can only be tuned against real enrolments.

**Tests:** `.ambiguous` when two candidates sit inside the margin; `.confident` at exactly
`margin`(boundary); `.none` unchanged below threshold; three-way ambiguity lists all of them;
mismatched-length candidates still skipped; `bestMatch` byte-identical to today across a fixture set.

---

## Item 2 — Unbounded thinking on the tool-calling turn (latent, structural)

**The finding as reported elsewhere:** a long system instruction plus a full tool-declaration set
plus unbounded thinking produced a **200 with `finishReason STOP` and zero output tokens** — not
truncation — reliably, on exactly the queries that should have triggered a search tool. Capping the
thinking budget eliminated it in every reproduction.

**Why we're exposed, and worse than they were.** [`LLMService.swift:2317`](../../OpenGlasses/Sources/Services/LLMService.swift:2317)
builds the Gemini tool-calling turn with our full system prompt, the whole tool-declaration set when
`includeTools`, and:

```swift
"generationConfig": ["maxOutputTokens": includeTools ? 1024 : Config.maxTokens]
```

No `thinkingConfig`. On a thinking model, thinking tokens are drawn from the same output budget — so
an unbounded thinking pass can consume the entire 1024 and leave nothing for the answer. That
presents as an empty completion whether or not their exact failure mode is involved, and the tool
path is the one where it costs the most, because it's the turn that was about to *do* something.

The asymmetry is the tell: [`GeminiLiveService.swift:380`](../../OpenGlasses/Sources/Services/GeminiLive/GeminiLiveService.swift:380)
already sets `thinkingBudget: 0`. The live path was capped; the REST tool path never was.

**Why it would be invisible.** We already detect empty completions
([`LLMService.swift:2395`](../../OpenGlasses/Sources/Services/LLMService.swift:2395)) and classify
them `retryOtherModel`, so the cascade quietly hops to another model and the user gets an answer.
That's good behaviour and bad observability: a systematic, reproducible defect would look like
ordinary model churn in the usage tracker. We would degrade forever without ever learning why.

**Core + wiring.**
- Explicit `thinkingConfig.thinkingBudget` on the Gemini REST tool path, and raise `maxOutputTokens`
  so the budget is a floor for the answer rather than a competitor to it. Both as named constants
  with the reasoning attached, not bare literals.
- A pure `GeminiBudgetPolicy` mapping (model, `includeTools`) → budget, so the choice is
  table-tested rather than sprinkled at call sites. Structured-vision paths (`:1175`, `:1268`) use
  the same policy — they carry a `responseSchema` and no tools, so they're lower risk, but they
  share the budget-competition mechanism.
- An empty completion gets a **distinct log marker and a usage-tracker note** (Plan AU) before it
  cascades. Same failure handling, no longer anonymous.

**Tests:** policy table across model × tools; body-shape assertions that the tool request carries a
budget and that the answer allowance exceeds it; empty-completion classification unchanged
(`retryOtherModel`) but now accompanied by the marker.

---

## Item 3 — The utterance we silently swallow (real, different shape than reported)

**Reported elsewhere as** answers landing one turn behind: nothing suspended the mic between
"STT recognised a final utterance" and "its answer reached TTS", so a second utterance spoken during
that 1–3 s network window overwrote the first one's context.

**That bug is not ours.** [`OpenGlassesApp.swift:1750`](../../OpenGlasses/Sources/App/OpenGlassesApp.swift:1750)
guards the window:

```swift
guard !self.isProcessing else {
    print("⚠️ Transcription ignored - already processing")
    return
}
```

Answers cannot land on the wrong question. But look at what the guard *does*: it discards the user's
speech behind a debug `print`. No tone, no HUD, no log the user could ever see. Someone who speaks a
second thought while the first is still in flight is simply ignored, with no signal distinguishing
"I didn't hear you" from "I heard you and threw it away" — so the natural response is to repeat
themselves into the same guard.

Same window, same root cause, a different and quieter failure. Suspending capture across the window
is better than discarding after the fact: nothing half-heard is ever collected.

**Core.** `TurnAdmissionPolicy` — pure, over (isProcessing, elapsed-since-dispatch, utterance):
`.accept` / `.deferToQueue` / `.rejectWithCue`. One deferred utterance is held, not a queue; a
second replaces it (the user's latest intent wins) and the holding slot expires so a stale phrase
never arrives minutes later attached to nothing.

**Wiring.** Suspend recognition on dispatch and resume when the turn completes, so the common case
never reaches the policy at all. Where something is still rejected, it gets an audible cue —
`playTone` already exists — and a HUD flash via `glassesDisplay.flash`, so the wearer knows the
words didn't land.

**Tests:** admission table; the held utterance survives exactly one turn and expires after it;
a second deferral replaces rather than queues; accept-path unchanged when idle.

---

## Item 4 — A question needs a longer pause than a statement (small, pure)

`TranscriptionService.silenceThreshold` is a flat `2.0` s, after which `returnToWakeWord()` ends the
conversation. Reported elsewhere in a much more severe form (a session torn down ~250 ms after TTS,
wiping history before any reply was possible, producing an infinite re-ask loop) — **we don't have
that bug**, because we end on silence rather than on speech-completion.

But 2.0 s is a statement's pause, not a question's. When the assistant's own answer ends in a
question — a disambiguation, a save confirmation, Item 1's new "Sam or Alex?" — the user has to
*think*, and thinking reliably takes longer than two seconds. The conversation ends underneath them
and their answer arrives as a fresh wake-word utterance with no idea what it's answering. Item 1
makes this more likely by design, which is why it's in this plan rather than deferred.

**Core.** `SpeechContinuationPolicy.silenceWindow(afterSpeaking:)` — a longer window when the
just-spoken text is question-shaped, the normal one otherwise. Pure, string-in/interval-out. Question
detection is deliberately dumb (terminal `?`, plus the handful of question-shaped endings TTS
sanitisation strips punctuation from); this is a comfort window, and over-generously waiting is
cheap while cutting someone off is not.

**Tests:** question and statement windows; punctuation-stripped question forms; window is *never*
shorter than today's 2.0 s for any input.

---

## P3 — Deferred to device

- Item 0's cost in practice: whether a Vision pass plus a blur composite at ~1 fps is invisible on
  the live path, and whether the pinned card visibly shows the blur (it should — that is the user's
  only feedback that the filter is doing anything).
- Item 1's `margin` default, tuned against real enrolments — a synthetic faceprint fixture can prove
  the *policy*, never the number.
- Item 2 against a live Gemini key: confirm the budget removes empty completions on tool turns, and
  that no answer gets truncated by the new ceiling.
- Item 3's suspend/resume across real Bluetooth route changes, and whether the deferred-utterance
  slot feels like memory or like lag.
- Item 4's window length in conversation.

## Decisions taken

1. **`.ambiguous` is spoken** (decided 2026-08-08). And phrased as a real question — "That might be
   Sam or Alex — which one is it?" — for three reasons: it is honest about the app's state, it lets
   the normal conversation loop act on the reply through the existing face tools, and it has to
   *read* as a question for Item 4 to grant the longer silence window. A statement-shaped prompt
   would close the window before the user could answer, which is worse than the confident wrong
   guess it replaces. `FaceRecognitionService.ambiguityPrompt` is the single source both the app and
   the tests use, so the phrasing and the window can't drift apart.
2. **A near-tie also blocks enrolment.** Not in the original plan, found while wiring: the enrolment
   path *renames an existing record* on a match, so acting on a near-tie there is the destructive
   form of the same bug — enrolling one sibling would silently rewrite the other's name. It now
   refuses and names the conflict.
3. **No encounter is logged on an ambiguous sighting.** Writing the wrong person into the encounter
   history outlives the moment and quietly corrupts every later "when did I last see…" answer.
4. **Thinking budget is non-zero** (decided 2026-08-08). 512 tokens of deliberation against a 2048
   allowance, so the answer keeps at least the 1024 it used to have to itself. This is the turn that
   chooses among 36+ tools and fills in their arguments — the step that most benefits from a moment's
   thought — so zero would have been the cautious choice rather than the right one. Plain turns are
   untouched: no `thinkingConfig` key at all, `Config.maxTokens` as before.

## Open questions

1. **Does the ambiguity outcome belong in the tool surface as well as auto-announce?** Currently
   auto-announce only. The tool's caller is a model that could ask a better-targeted question than a
   fixed string.
2. **Recording and broadcast blur** (Item 0). Needs an off-main pipeline; scoped out deliberately.
