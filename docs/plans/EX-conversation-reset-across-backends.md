# Plan EX — Conversation Reset Across Backends

**Status: 🚧 Core shipped 2026-09-16** — `ConversationResetCoordinator`, all backend adapters and
the marker tests are in. Owed: one live round-trip per backend against its real context/resumption
behaviour, and recognition + spoken-cue validation on glasses. The temple double-tap investigation
is closed (unavailable — see below).

## Gap and existing coverage

`ConversationClassifier` routes whole reset utterances to `NewTopicTool`; the tool posts
`ogNewTopicRequested`. AppState clears `LLMService` history with an in-flight-safe deferral
and starts a persistence thread. The observed handler does not establish reset of Gemini Live,
OpenAI Realtime, OpenClaw or Hermes server-side context. This is an unverified boundary to audit,
not a claim that every backend is broken. [BR](BR-realtime-and-stream-hardening.md) already
owns deliberate gateway session-key rotation; [EB](EB-action-reach-and-conversation-continuity.md)
owns saved-thread selection. Reuse both.

## Scope and build order

1. Record each mode's context owner, reset API and completion signal. Design one deterministic
   reset coordinator with explicit requested/in-flight/completed/failed outcomes and a generation
   boundary. Use existing phrase matching and the existing tool; do not add another command router.
2. Route voice, model tool calls and the UI new-conversation action through it. Clear local history
   and start exactly one saved thread on a successful reset. When a reset is invoked inside a tool
   turn, finish the required tool response before retiring that context; reject late old-generation
   output from both the new transcript and spoken audio.
3. Adapt every supported backend: clear context through a supported API, rotate the deliberate
   remote session key, or reconnect to a fresh session as required. Clear live resumption handles
   where reuse would restore the old context. Unsupported or failed resets give an honest result;
   never confirm success after only clearing the phone's display.

## What shipped

One coordinator (`Sources/Services/ConversationReset/`) behind all three entry points — the
classifier's Tier-0 phrase route, the model calling `new_topic`, and the conversation UI's
new-chat action. The per-owner inventory that shaped it is [EX-reset-inventory.md](EX-reset-inventory.md).

- **Outcomes** are `completed`, `issuedUnverified`, `failed` and `unsupported` per backend. The
  phone's history is cleared and exactly one saved thread started only when every backend in the
  plan crossed the boundary; otherwise nothing local changes and the confirmation names what held
  out.
- **The generation boundary** advances when a reset is *requested*, not when it finishes: while the
  reset runs, the conversation being retired is still producing an answer. Every turn captures the
  generation at its start and both the transcript (`accept`) and the speaker (`speak`) reject a
  stale one; speech already in flight is stopped at the request.
- **The turn barrier** (`LLMService.isTurnInFlight`, a depth rather than a flag because
  `sendMessage` → `sendLocal` nests) holds the reset until the turn has finished owing the model
  its tool results.
- **`new_topic` no longer claims success.** It returns a neutral acknowledgement; awaiting the
  reset from inside the tool would deadlock against the barrier, and the coordinator owns the
  spoken cue.

## Acceptance

A scripted backend remembers a unique marker before reset and does not receive it in the next
turn's context after reset. Test idle, speaking, tool-in-flight, reconnect, repeated requests and
failure for Direct/cloud, local/offline, Gemini Live, OpenAI Realtime, OpenClaw and Hermes where
configured. Assert thread creation count, tool-response ordering and stale-output rejection.
Persistent notes, BrainStore memories, settings and historical saved threads are not deleted.
Explicit long-term recall may still retrieve saved memories; this command resets current context.
A success cue is emitted only after the selected backend crosses the reset boundary.

## Live edge and gesture decision

Verify one reset round-trip per backend against its actual context/resumption behavior, sharing
[EH](EH-openclaw-2-0-wire-alignment.md)'s gateway fixture. Validate recognition and spoken cues
on glasses. Both are owed.

**Temple double-tap: unavailable — investigation closed 2026-09-16.** The pinned SDK (0.9.0) was
read directly: `MWDATCore`, `MWDATCamera` and `MWDATDisplay`'s `arm64-apple-ios.swiftinterface`
declare no gesture, touch, temple, hardware-button or input-event API of any kind. The only `tap`
and `button` symbols in the whole surface are in-lens HUD view components — `Button(label:style:
iconName:onClick:)` and `FlexBox.onTap(_:)` — which fire when the wearer selects a rendered control
on a Display device, not when they tap the frame. There is no supported event to bind, so nothing
was added and nothing is promised; the voice route was never made to depend on one.
