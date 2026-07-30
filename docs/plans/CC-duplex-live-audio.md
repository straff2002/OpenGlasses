# Plan CC — Duplex Live Audio (echo cancellation that degrades instead of failing)

**Status:** 🚧 P1+P2 shipped in one PR (2026-07-31) — `DuplexAudioCapability` + `VoiceProcessingProbe`
(zero-rate dead-IO verdict) + `EchoSuppressionPolicy` (truth table replaces the inline mute in **both**
session managers), engine container replaced only in `prepareEngineOnQueue` at capture start on the
lifecycle queue (VP enabled before any wiring/format read; dead-IO → rebuild without VP), tier logged
per capture start, `duplexAudioEnabled` flag default **off**. Resolved open decisions: VP is retried
per capture start with the verdict held for that capture (no mid-conversation flapping), and the flag
is not user-visible — the reached tier is in the capture-start log. VP is only attempted in iPhone
mode: glasses mode has a remote mic and no echo path, so the IO-swap risk buys nothing there.
**P3 (device matrix) owed and gates default-on** — checklist in the phase section below.

## Problem

**In phone mode, the user cannot interrupt the assistant.** One line does it:

```swift
// GeminiLiveSessionManager.swift:155
if self.useIPhoneAudioMode && self.geminiService.isModelSpeaking { return }
```

Every captured buffer is dropped for the entire time the model is speaking. The mute is there for
a real reason — a loudspeaker beside an unprocessed mic feeds the model its own voice, and it will
interrupt itself or produce garbled output. But the cost is that the Live API's server-side VAD
*never hears the user*, so the interruption detection it already provides has nothing to fire on,
and the existing `onInterrupted` handling is unreachable in phone mode.

The consequence is worst exactly where it matters: a long or wrong answer has to be waited out.
Glasses mode (`videoChat`, mic on the remote device) is unaffected — this is a phone-mode-only
defect.

## The three-outcome landscape (and two dead ends to skip)

This problem has a well-documented shape. Three configurations, and the two obvious ones are both
wrong:

| Approach | Failure |
|---|---|
| **Mute mic while model speaks** (current) | Model is **deaf during its own speech** — no barge-in. |
| **Enable voice processing on a long-lived `AVAudioEngine`** | Capture is silenced **entirely** on recent iOS betas — model is deaf *always*, strictly worse. |
| **Fresh engine per capture start, voice processing enabled before any wiring** | Works — and fails *detectably* when it doesn't. |

The second row is the trap that matters here, because it is precisely the shape of our code:
`RealtimeAudioEngine` holds `private let audioEngine = AVAudioEngine()` — a **long-lived** engine —
and `startCaptureOnQueue()` reads `inputNode.outputFormat(forBus: 0)` before doing anything else.
Enabling `setVoiceProcessingEnabled(true)` on that engine, in that order, is the configuration that
silences capture. Anyone reaching for VPIO here without restructuring the lifecycle will land on
the worse of the two failures and be tempted to conclude VPIO is unusable.

The reason both fail is the same: the IO unit swap only behaves when its ordering is deterministic.
Voice processing has to be enabled **before** any node wiring and **before** any format read, on an
engine that was built fresh for this capture.

## Approach: layered, not binary

Enable the system voice-processing IO — the same echo cancellation the platform's own video-calling
uses. Playback and capture share one engine here, so the canceller receives the exact reference
signal and the mic can stay open while the model talks.

Then make failure *graded* rather than fatal:

1. Build the engine fresh on every capture start.
2. Enable voice processing on the input node **before** wiring and **before** reading any format.
3. Read the input format. **A zero sample rate is the dead-IO signature** — the exact condition
   that silences the beta path. Treat it as a thrown error.
4. On that error, rebuild the engine **without** voice processing and re-enable the
   mute-while-speaking gate for that path only.

The result is three-tiered instead of all-or-nothing:

- **Echo cancellation working** → continuously open mic, real barge-in.
- **Echo cancellation unavailable** → mute-while-speaking (today's behaviour, no regression).
- **Deaf-always and hearing-itself** → both structurally off the table.

Turn-taking otherwise stays server-side, which is the Live API's documented default mode: the mic
streams continuously and the server VAD owns endpointing and interruption. The session keeps
`.voiceChat` mode for OS-level echo tuning.

**If residual echo leaks past the canceller, the model will cut itself off with nobody speaking.**
The lever for that is start-of-speech sensitivity in the session config — documented, adjustable,
and server-side — *not* re-muting the mic. Writing this down because the instinct on seeing
self-interruption is to reach straight back for the mute, which throws away barge-in to fix a
tuning problem.

## Surfaces

- `RealtimeAudioEngine` (`Sources/Services/Audio/`) — engine lifecycle, VPIO enable, dead-IO
  detection, capability reporting. Shared by Gemini Live and OpenAI Realtime, so both modes get
  this at once.
- `GeminiLiveSessionManager` / `OpenAIRealtimeSessionManager` — the mute gate becomes conditional
  on the reported capability rather than on `useIPhoneAudioMode`.
- `AudioInterruptionPolicy` — unchanged, but the fresh-engine-per-start change touches interruption
  recovery, so its existing tests are the regression net.
- Interaction with `AudioSessionLeaseCoordinator`: rebuilding the engine mid-session must not drop
  the lease. Verify against the existing lease tests, don't add a second owner.

## Phases

### P1 / PR1 — Pure core 🟢
- `DuplexAudioCapability` — `.echoCancelled` / `.halfDuplex`, derived from what the engine build
  actually achieved, published for the session managers to read. Never inferred from OS version.
- Pure `VoiceProcessingProbe` — given an input format, decides usable vs dead-IO (zero sample rate,
  zero channels), returning a typed reason. This is the whole detection rule, testable with no
  audio hardware.
- Pure `EchoSuppressionPolicy` — given capability + `isModelSpeaking`, decides whether a captured
  buffer is sent or dropped. The mute gate becomes a pure function with a truth table instead of
  an inline condition.
- Restructure `RealtimeAudioEngine` to build the engine per capture start (behaviour-preserving on
  its own: capability stays `.halfDuplex` until P2 flips VPIO on).
- Tests: probe verdicts across format shapes, policy truth table (all four capability ×
  speaking combinations), engine rebuild leaves no stale tap installed, lease not dropped across
  rebuild, interruption recovery still passes.

### P2 / PR2 — Enable VPIO behind a flag
- `setVoiceProcessingEnabled(true)` in the correct position in the new build sequence, guarded by
  `duplexAudioEnabled` (default **off** until device verification).
- Fallback rebuild path on probe failure; capability published; session managers consult
  `EchoSuppressionPolicy`.
- One-line log of which tier was reached at every capture start — the first question on any field
  report will be which of the three outcomes the device landed on.

### P3 / PR3 — Device verification, then default on
Device-pending, and the gate for flipping the default. Checklist:
- Phone-speaker barge-in actually interrupts mid-answer.
- No self-interruption with nobody speaking. If present, tune start-of-speech sensitivity — do not
  re-mute.
- Bluetooth/AirPods route and mid-session route change (the fresh-engine change is most likely to
  bite here).
- Glasses mode unchanged (mic on the remote device, `videoChat`).
- Fallback tier reachable and correct: force the probe to fail and confirm half-duplex behaviour
  matches today's.
- Power/thermal cost of a continuously open mic under Plan BV `.reserve`.

## Open decisions

- **Does the fallback tier need to retry VPIO on the next capture start, or stay half-duplex for
  the session?** Retrying is cheap (the engine is rebuilt anyway) but risks flapping capability
  mid-conversation. Leaning: retry per capture start, hold the verdict for the duration of that
  capture.
- **Should `duplexAudioEnabled` be user-visible?** Leaning no — it is a capability, not a
  preference, and the fallback is automatic. Surface the reached tier in the audio diagnostics
  view instead.

## Escape hatch

If VPIO cannot be made to behave across the device matrix, the honest fallback is not today's
silent mute but a **client-side interrupt affordance**: keep half-duplex, and let a tap (or the
existing `cancelResponse()` on the Realtime path) stop the model. Worse than barge-in, but it at
least gives the user a way out of a wrong answer, which is what the mute currently denies. P1's
pure core is useful either way.
