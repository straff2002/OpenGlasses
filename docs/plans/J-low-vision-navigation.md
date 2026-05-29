# Plan J — Low-Vision Navigation Assist

**Variant of:** [Plan A3](A-accessibility-tier.md) Assistive Modes. Reuses the `AssistiveModeService` ambient-loop pattern (timer → frame → `LLMService.analyzeFrame` → parse → speak) and `SpeechUrgency`, but tuned for **obstacle/hazard awareness** for low-vision users walking through a space.

**Strategic fit:** Extends the Accessibility tier with its most impactful real-world use case. Distinct from A3 Scene mode (which is general situational info) — this is movement-focused: hazards, drop-offs, doors, steps, oncoming people.

**Effort:** ~2-3 days.

---

## What already exists

- `AssistiveModeService` — the ambient capture/analyze/speak loop, with overlap guard and "don't talk over speech."
- `AssistiveAdvice` — `{advice, urgency, followup?}` JSON parser + `urgency → SpeechUrgency` bridge.
- `LLMService.analyzeFrame` — stateless vision call.
- Wake-word gate in `OpenGlassesApp` (mode owns the loop while active).

## New work

**Add a `navigation` mode** rather than a whole new service — extend `AssistiveRouter.Mode` with `.navigation`, or add a `NavigationAssistService` if the cadence/behavior diverges enough. *Recommendation: a dedicated `NavigationAssistService`* — navigation wants a **faster interval** (~2s), **hazard-first prompt**, and **distance/clock-position phrasing** ("step down, two o'clock, about one meter"), which differs enough from A3's calm scene/social tone to justify separation while still reusing `AssistiveAdvice` + the loop skeleton.

**Navigation system prompt** (strict JSON, same schema as A3):
> "You are a mobility aid for a low-vision user who is walking. Report only movement-relevant hazards and landmarks: steps, drop-offs, doors, obstacles, oncoming people/vehicles. Use clock positions and rough distance. One sentence, ≤15 words. urgency: low=clear path, medium=obstacle to navigate, high=immediate hazard (drop-off, vehicle, collision). If the view is unclear, say 'view unclear'."

**Hazard escalation:** map `high` urgency → `SpeechUrgency.high` (faster + "Important:" cue) — already wired through `AssistiveAdvice.Urgency.speechUrgency`.

**Files:**
- `Sources/Services/Accessibility/NavigationAssistService.swift`
- `Sources/Services/NativeTools/NavigationAssistTool.swift` (`navigation_assist` start/stop/status) — or a toggle in the Accessibility UI.
- Touch: `AccessibilitySettingsView` (toggle), `NativeToolRegistry` (register, camera-gated), both system prompts.

## Safety considerations (do not overclaim)

- This is an **assistive aid, not a primary mobility device** — must say so on first activation and in Settings. Never replace a cane/guide dog framing.
- Bias toward false-positive hazard warnings over silence, but cap repetition with the same dedup approach as `LiveCoachService.isSimilar`.
- Pause analysis when the frame is dark/blurred (cheap luminance/variance check before the LLM call — saves tokens and avoids confident wrong calls).

## Build order

1. `NavigationAssistService` from the `AssistiveModeService` template + hazard prompt.
2. Frame-quality pre-check (skip LLM on dark/blurred frames).
3. Dedup + urgency wiring.
4. Tool/toggle + prompts + disclaimer copy.

## Open questions

- On-device hazard pre-detection (Vision rectangle/horizon, depth on LiDAR devices) before the LLM call, to cut latency/cost and improve drop-off detection?
- Haptic cues (taptic) in addition to TTS for high-urgency hazards?
- Interval: fixed 2s, or adaptive (faster when motion detected via accelerometer)?

## Dependencies

- A3 loop + `AssistiveAdvice` + `analyzeFrame` (shipped). Accessibility tier gating.
