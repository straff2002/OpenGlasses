# Plan C — Live Coach Tool

**Source repo:** [sidelineiq](https://github.com/prasanthsasikumar/sidelineiq)

**Strategic fit:** Generalizes sidelineiq's 2s frame-loop pattern into a multi-domain tool. Reuses existing `CameraService.framePublisher`. One-sentence tactical feedback for any visual domain.

**Effort:** ~1-2 days

---

## Files

- New: `Sources/Services/NativeTools/LiveCoachTool.swift`
- New: `Sources/Services/LiveCoachService.swift` — manages session lifecycle, interval timer, frame capture, dedup, output throttling
- Touch: `NativeToolRegistry.init()` — register
- Touch: `project.pbxproj` — standard four-entry pattern
- (Confirm) `Sources/Services/CameraService.swift` — verify `framePublisher` exposes ready-to-encode frames

---

## Tool spec

```
live_coach:
  args:
    action: "start" | "stop" | "status"
    domain: "sports_tactics" | "cooking_form" | "posture" | "guitar" | "climbing" | "custom"
    custom_prompt?: string         // required when domain="custom"
    interval_seconds?: 1-10        // default 2 (matches sidelineiq)
    max_words?: number             // default 20
    max_duration_minutes?: number  // default 30 (safety cap)
  returns: session id / current status
```

---

## Per-domain system prompts

All share: one sentence, ≤max_words, no markdown, identify issue + suggest fix in same breath. Adapted from sidelineiq's "claude-opus-4-5, max 80 tokens" pattern.

| Domain | Prompt focus |
|---|---|
| `sports_tactics` | Identify tactical problem + solution in plain language |
| `cooking_form` | Knife grip, cutting technique, heat/stove safety, ingredient ordering |
| `posture` | Spine alignment, shoulder position, screen distance, ergonomic issues |
| `guitar` | Finger placement, chord shape, wrist angle, picking technique |
| `climbing` | Route reading, weight distribution, balance, next hold suggestion |
| `custom` | Use `custom_prompt` verbatim |

---

## Service flow

1. `LiveCoachService.start(domain, interval)` — kick off timer, subscribe to `CameraService.framePublisher`
2. Every `interval` seconds, grab latest frame → JPEG quality 0.7 (matches sidelineiq compression)
3. Send to LLMService with domain prompt
4. **Dedup check:** Skip TTS if new advice cosine-similar to last advice within X seconds (avoid repetitive "fix your grip / fix your grip / fix your grip")
5. Emit to TextToSpeechService
6. Auto-stop after `max_duration_minutes` or explicit `stop` action

---

## Build order

1. `LiveCoachService` skeleton with start/stop, no LLM yet
2. Wire frame capture from CameraService
3. Add per-domain prompts + LLM call
4. Add dedup + throttle
5. Wire into `LiveCoachTool` NativeTool
6. Voice trigger test: "coach my squat form" → tool start → domain=posture

---

## Open questions

- **Cost cap:** Hard limit on API calls per session? Recommendation: enforced by `max_duration_minutes * (60/interval_seconds)` ceiling.
- **Visual output:** Should advice also display on phone screen for later review/sharing, or audio-only?
- **Pause when out-of-view:** Skip LLM call when frame is dark/blurred/no subject detected? Could save tokens; needs lightweight scene-change detector.
- **Domain extensibility:** Open up `custom` mode publicly, or keep it gated behind a hidden flag for trusted users?

---

## Dependencies / prereqs

- Existing `CameraService.framePublisher` must yield JPEG-encodable frames
- Existing `TextToSpeechService` (use `.medium` urgency from Plan A2 if implemented — tactical advice is meaningfully time-sensitive)
- LLMService must support vision-capable model (Claude/Gemini both work)
