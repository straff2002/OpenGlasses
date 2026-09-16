# FF P1/PR4 — How a reading request reaches a sharp capture

Audit of the existing routes, the finding that justified the deterministic assist, and the assist
that was chosen. Companion to [FF-blind-assistant-readiness.md](FF-blind-assistant-readiness.md).

Baseline: worktree on `feat/ff-p4-reading-detail` from `c1db0f67`, build 398. Source inspected, not
a device trace — no live model output has been captured against any of this.

## The question

A blind wearer says one of: "read this", "what does this say", "what's the expiry date", "read the
menu", "what does this label say". What has to happen for that to end in a full-resolution photo
being read, and what decides it?

## The routes, as they actually are

| Path | What decides | What happens |
|---|---|---|
| Blind Assistant live session (Gemini Live / OpenAI Realtime) | **The model**, from `look_closely`'s tool description | Model emits `look_closely` → capture → inject into its own view → read from the image |
| Blind Assistant live session, model does not call the tool | nothing | The model answers from the throttled stream frame, which is the picture that cannot resolve the print |
| Direct mode (wake word) | **The model**, from `reading_assist`'s tool description | `reading_assist` → on-device OCR → the mode directive and the captured text go back as a tool result |
| Direct mode, `ConversationClassifier` Tier 0 | deterministic, by phrase | **No reading route exists.** Tier 0 covers time, music, flashlight, scan assist, steps, battery, weather, calendar, new topic |
| Assistive mode / narration / navigation | a periodic loop, not a request | These describe the environment; they are not reading routes |

### Finding 1 — the model was never told the wearer's words

`look_closely`'s description named "small print, receipt line items, serial numbers, gauge or
instrument markings, distant signs". Not one of the five phrases above appeared in it. The model was
being asked to make the leap from "read me this label" to "instrument markings" unaided, and nothing
downstream would notice if it did not: answering from the stream frame produces a fluent, confident,
possibly wrong reading rather than a visible failure.

The Plan FF P0 contract's `faithfulReading` fragment governs *how* text is read once it is legible —
exact transcription versus partial versus interpretation, never fill in a medication name — and says
nothing about how to obtain a picture good enough to read. The two halves did not meet.

### Finding 2 — the fallback pointed at a tool that does not exist

`look_closely`'s no-live-session result told the model to "use a vision tool such as `vision_assess`
or `read_text`". There is no `read_text` tool in the registry. The real one is `reading_assist`.

### Finding 3 — `reading_assist` is not always registered

`reading_assist`, `identify_color`, `identify_money` and `navigation_assist` are registered only
when `Config.accessibilityModeEnabled`. `look_closely` is registered whenever a camera exists. So a
wearer on the Blind Assistant preset with accessibility mode off has the sharp-capture tool and no
reading tool. That is recorded here and deliberately not changed in PR4: the registration gate is a
settings question, and changing which tools a wearer's model sees is not a reading-quality change.

### Finding 4 — Direct mode has no deterministic reading route, and should not get one here

Tier 0 exists for requests the app can answer without an LLM turn, and every current entry takes no
arguments: the clock, the step count, the battery. A reading request needs a mode, sometimes a
question, sometimes a target language — `reading_assist` takes five modes and four parameters — so a
Tier-0 route would have to either guess them or route every reading phrase to a bare `read`, which
would break "what's the total on this receipt" (an `ask` with a question) and "translate this sign".
It would also route to a tool that may not be registered (Finding 3). Left to the model, recorded.

### Finding 5 — nothing verified the picture

Separate from routing, and the larger of the two problems. Once `look_closely` did fire, a capture
that returned without throwing was injected. Nothing measured whether it was sharp, whether it was
lit, whether it had been through the privacy filter, or whether it still belonged to the
conversation that asked for it. That is what the rest of PR4 is about; it is recorded here because
"the model reliably calls the tool" is worth very little on its own.

## The deterministic assist that was chosen

**Strengthen the tool description, from a shared vocabulary. Do not add a router, and do not
pre-capture.**

`ReadingRequestClassifier` is a pure predicate over an utterance with three consumers:

1. `LookCloselyTool.description` composes `triggerPhrases` into the description the model selects
   from, so the phrases the model is shown and the phrases the app recognises cannot drift. A test
   asserts every advertised phrase is one the classifier recognises.
2. The degraded-capture copy: a reading request gets "move a little closer to the text", anything
   else gets the general hold-steady line. Wrong advice costs a wearer who cannot check it a move
   across a room.
3. Whether a degraded capture is worth an on-device recognition pass for a partial transcription.

None of the three can fire a camera that policy would not already have fired, which is what makes a
false positive cheap and a partial multilingual vocabulary acceptable. An unrecognised language
falls through to the model's own tool selection — the behaviour that exists today — never to
something worse.

### What was rejected, and why

**Pre-capturing a sharp still before forwarding a reading turn.** It would put the picture in front
of the model before it asked, which is the reliable version of this. It was rejected for PR4 because
it requires owning the live turn boundary — transcription arrives, classify, capture, inject, then
release the turn — and that boundary is where Plan FF PR5's reconnect and resumption work lands. Two
plans editing the same seam in the same week is how a race gets shipped. It is the natural PR5/PR6
follow-on and is recorded as such rather than as done.

**A Tier-0 route in `ConversationClassifier`.** Finding 4.

**A new fragment in `BlindAssistanceContract`.** The contract is shared by eight composition paths
and its ordering is pinned by tests; a "use the sharp capture tool" rule would reach narration and
navigation, which have no such tool. The instruction belongs on the tool, where only the paths that
have it can read it.

**Raising streamed-frame quality or rate.** Explicitly out of scope per the plan, and the wrong
trade: it would pay continuously for something needed occasionally.

## What is still unproven

The audit is a reading of the source. That the model *now* calls `look_closely` on "read this" is
not established by any of it — only that it is now told to. The device evidence PR4 owes is a
session per trigger phrase under the Blind Assistant preset on real glasses, recording the model and
version, whether the tool fired, and what was said.
