# Plan EX — Conversation Reset Across Backends

**Status: 📝 Drafted 2026-09-12; not scheduled.** One implementation PR, core and fake
backend tests first; live backend/device validation follows.

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
on glasses. A temple double-tap is an optional investigation: inspect the installed SDK and
current official capabilities before adding it. If no supported event exists, record unavailable
and close that investigation; do not promise or block the voice feature on a gesture.
