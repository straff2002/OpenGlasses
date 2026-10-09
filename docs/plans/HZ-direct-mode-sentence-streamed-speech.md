# Plan HZ: Direct-Mode Sentence-Streamed Speech (start talking at the first sentence, not the last token)

**Status:** 📝 Drafted 2026-10-10. Nothing built. P0 is a pure core; P1 wires it into the Direct turn
behind a flag that defaults off until P2's device numbers; P2 is a device measurement read through
Plan [CU](CU-voice-turn-latency.md)'s `ttsLeadIn`.
**Origin:** The [October 2026 ecosystem review](../ecosystem-review-2026-10.md) (section 3 row
"Direct-mode replies are not sentence-streamed"; section 5; Appendix B claim 4).
**Why a new plan and not a CU phase:** CU was checked first. It names sentence streaming as the
thing its signed `ttsLeadIn` exists to measure and records that no Direct spine can produce a
negative lead-in today (`docs/plans/CU-voice-turn-latency.md:146-151`), but no CU phase owns
building it: P2 is acoustic end-of-turn, P3 local time-to-first-token, P4 wake-word pre-roll, P5
device measurement. This plan builds it; CU's row and file carry a dated pointer here, and CU's
instrumentation is this plan's acceptance test.
**Priority:** The largest remaining latency in a cloud Direct turn after end-of-turn detection: a
long answer is generated in full before the first word is spoken.
**Surfaces:** One pure splitter and gate, a prefetching speech queue inside
`TextToSpeechService`, the Direct turn's `onToken`/`onStreamReset`/`speak` closures. No new
dependency, no change to any provider's request.

Evidence under `OpenGlasses/Sources/`; line numbers as recorded by the review at `7a0cc0e0`,
re-read on `main` at `48bcae0c`.

---

## Why

- **One caller.** `TextToSpeechService.speakStreaming(_:)` (`Services/TextToSpeechService.swift:596`)
  is called only from the OpenClaw gateway stream (`App/OpenGlassesApp.swift:3030`).
- **Direct mode speaks at the end.** The Direct turn's `onToken` appends to the chat bubble only
  (`App/OpenGlassesApp.swift:6856-6858`); the `speak:` closure hands the whole reply to
  `speechService.speak(response)` after generation ends.
- **The existing streamer is not good enough to reuse as it is.** It cuts at the last `.`, `!`, `?`
  or newline in the buffer, so "2.5 mm", "e.g." and "Dr. Patel" split mid-phrase; and it awaits the
  previous sentence's playback before *starting* the next one's synthesis, so with a cloud voice
  every sentence pays a full round trip of silence.

## Scope

**In:** a sentence splitter with abbreviation, number and list guards; a hold-back gate for text
that later processing could still change; a speech queue with two or three synthesis requests in
flight; barge-in and conversation-reset behaviour for a partly spoken reply; a per-reply cloud
voice demotion after two consecutive failures; all three cloud providers' Direct paths and the
local MLX path (whose token callback already exists).

**Non-goals:**
- Gemini Live and OpenAI Realtime, which stream audio natively.
- Changing what is said. The spoken text is the same text `speak(response)` would have received;
  only its timing changes.
- Word-level streaming into the synthesiser. Sentences are the unit: prosody needs them and every
  engine in the chain accepts them.
- The HUD. Paged answers are Plan [IB](IB-paged-hud-answers.md).

## Design

### 1 · `SentenceStreamSplitter` (pure)

Feeds on token chunks, emits complete sentences. A boundary is `.`, `!`, `?`, `…` or a blank line,
followed by whitespace and then an upper-case letter, a digit, a quote or end of stream, **unless**:
- the word before a `.` is in an abbreviation list (Mr, Mrs, Ms, Dr, St, e.g., i.e., etc., vs,
  approx, no, fig, and single capital initials);
- the `.` sits between digits ("2.5", "3.14") or inside a version or IP-like token;
- the text is inside an unclosed code span or fenced block (spoken replies rarely carry them, but a
  fence must never be cut open);
- a list item marker follows a newline (each item is a sentence of its own, which is the point).

A minimum sentence length (about 20 characters) merges a very short opener ("Sure.") into the next
sentence, so the first request is not a one-word synthesis. A maximum (about 300 characters) cuts
at the last comma or semicolon so a run-on paragraph does not delay the first audio.

### 2 · `StreamSpeechGate` (pure)

Decides when an emitted sentence may be handed to speech. It holds while:
- **think filtering is undecided.** `ThinkStreamFilter` (`Services/ThinkStreamFilter.swift`) strips
  reasoning blocks from local models; until it has seen the close of an open block, nothing after
  the open is released.
- **the reply may be a memory command or a tool preamble.** The turn path parses some replies after
  generation (memory loop, choice detection). The gate takes a `holdWholeReply` predicate evaluated
  on the text so far; when the first sentence matches a shape that later processing rewrites, the
  rest of the reply is spoken whole at the end, as today.
- **the reply carries choice buttons.** `presentChoiceButtonsIfDetected` (Plan CG,
  `App/OpenGlassesApp.swift:6267`) renders numbered options; a reply whose opening looks like a
  numbered choice list is held and spoken whole, so the spoken options and the buttons appear
  together.
- **a reset may follow.** `onStreamReset` (BM P9) drops an iteration's bubble text when a tool loop
  begins a new iteration. Sentences already spoken from that iteration stay spoken; open question 1
  decides what the transcript shows.

### 3 · Prefetching speech queue

Inside `TextToSpeechService`, a `StreamedReplyQueue` replaces the body of `speakStreaming` (the
OpenClaw caller keeps its API and gains the better splitter too):
- up to `prefetchDepth` (default 2, at most 3) sentences are being synthesised while one plays;
  playback stays strictly in order;
- each sentence walks the same `TTSEngineSelector` chain `speak` uses, with `CloudVoiceRejection`
  handling unchanged;
- **per-reply demotion:** two consecutive cloud synthesis failures inside one reply demote the
  rest of that reply to the next engine in the chain (Kokoro, else the system voice), so a flaky
  network does not produce a sentence-by-sentence stutter of timeouts; the next reply tries the
  cloud voice again;
- the queue carries the turn generation; `conversationReset.isCurrent(turnGeneration)` is checked
  before each sentence plays, so a reset mid-reply drops the rest without playing it.

### 4 · Barge-in and stop

- A barge-in (`WakeWordService.onBargeIn`) or "stop" cancels in-flight synthesis and drops queued
  sentences, recording the interruption through the existing `stopSpeaking(interruption:)` reason
  (Plan FE P4) with how many sentences were heard.
- The replay offer FE built ("you cut that off") replays from the first unheard sentence, not from
  the start, since the queue knows the boundary.
- Generation keeps running after a barge-in only as long as today's turn cancellation allows; this
  plan does not change turn cancellation.

### 5 · Measurement

`TurnRecorder` already stamps `ttsRequestedAt` and `firstAudioAt`; the first streamed sentence sets
both. A streamed turn should show a **negative `ttsLeadIn`** on the Developer panel. CU's cohorts
(backend × engine × mic route) are how P2 reads the result.

## Phases

### P0: pure core (one PR)

`SentenceStreamSplitter`, `StreamSpeechGate`, and the queue's ordering and demotion logic as a pure
`StreamedReplySchedule` (which sentence to synthesise next, which to play, when to demote) with an
injected synthesiser.

**Tests:** `SentenceStreamSplitterTests` (abbreviations, decimals, "2.5 mm" continuation, lists,
code fence, minimum merge, maximum cut, chunk boundaries falling inside a word and inside "e.g.");
`StreamSpeechGateTests` (think block held until closed; a choice-list opening held to the end; a
memory-command shape held; plain prose released per sentence); `StreamedReplyScheduleTests` (order
preserved with out-of-order synthesis completion, depth bound, two failures demote for the rest of
the reply only, reset drops the remainder).

### P1: wiring behind a flag (one PR)

`Config.directSentenceStreamingEnabled` (default **off** until P2; a Developer-panel switch).
Direct turn: `onToken` also feeds the splitter; `speak:` becomes "flush the queue" when streaming
ran, else today's `speak(response)`; `onStreamReset` informs the gate. OpenClaw's
`speakStreaming` moves onto the new queue. Barge-in and replay as in Design 4.

**Tests:** a turn-level test over the existing LLM fakes (`LLMStreamingTests` seams): tokens in,
sentences out in order, the full reply text equals the spoken text; a barge-in after sentence one
drops the rest and records one heard sentence; a reset mid-reply plays nothing further; the flag
off is byte-for-byte today's path. `TurnTimelineTests` gains a streamed turn with negative lead-in.

**Gates:** full suite and Release build green, `SWIFT_EMIT_LOC_STRINGS=NO`, privacy-logging gate.

### P2: device measurement (owed)

On both mic routes, Anthropic, OpenAI and Gemini Direct with ElevenLabs and with Kokoro, twenty
turns each: perceived time to first word, `ttsLeadIn` distribution, audible gaps between
sentences, barge-in mid-reply. If streaming is not clearly better on the glasses route, the flag
stays off and the numbers are recorded here. If it is, a one-line PR flips the default.

## Open questions

1. A tool-loop preamble spoken before a reset ("Let me check the forecast."): keep it in the
   transcript as a separate line so what was heard is what is shown (recommended), or suppress
   speech until an iteration is known to be text-only (no gain on tool turns)?
2. Prefetch depth 2 or 3? Depth costs cloud voice characters if the wearer barges in early; P2 sets
   it.
3. Should the system voice ever be the first engine for the opening sentence, to get audio out
   while the cloud voice warms? Recommended: no, a voice change mid-reply is jarring.

## Dependencies

- **CU** (🚧 P1 and P2 PR1 shipped; index and file agree): the measurement; dated pointer added
  2026-10-10.
- **FE** (✅): interruption reasons and replay.
- **BG** (✅): the Direct turn spine and its closures.
- **CG** (choice buttons) and the memory loop: the gate's hold rules.
