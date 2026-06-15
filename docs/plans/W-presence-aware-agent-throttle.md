# Plan W — Presence-Aware Agent Throttle

**Source pattern:** The presence-aware cycle-throttle / autonomy-downgrade idea from our idea-source repo `~/Code/qaeros` (`plans/510-presence-aware-agent-throttle.md`), reframed from "is the operator watching the dashboard" to "is the user actually engaging with the glasses". Concept only; clean-room Swift.

**Strategic fit:** Battery + safety for an always-on device. Any continuous loop — the Live Coach per-domain loop ([LiveCoachService](../../OpenGlasses/Sources/Services/LiveCoachService.swift)), the assistive/ambient caption loop, proactive alerts, and (once it lands) the [Plan S](S-plan-then-execute-and-safety-supervisor.md) agent loop — runs at a fixed cadence whether or not the user is paying attention. On a wearable that drains a small battery and can *act*, that's wasteful and slightly risky. This plan adds a single `PresenceMonitor` that fuses cheap on-device signals (motion, voice activity, time-since-last-command, glasses-connected state) into a 0–1 engagement factor, and a throttle that (a) scales loop frequency by that factor and (b) **downgrades autonomy** from act → recommend when the user has been disengaged for a while.

**Effort:** ~2–3 days.

---

## Concept (reframed for a wearable)

qaeros throttles server-side agent cycles by operator tab-focus. We don't have an operator at a screen — we have a person wearing glasses. The equivalent signals are local and cheap:

| Signal | Source | Meaning |
|---|---|---|
| Motion / activity | CoreMotion (`CMMotionActivityManager`) | walking/driving vs stationary |
| Voice activity | existing wake-word / transcription pipeline | recent spoken interaction |
| Time since last command | app state | how long since the user engaged |
| Glasses connectivity | DAT session state | are the glasses even on the face |
| Foreground | app lifecycle (+ Local Model Background memory: MLX can't run backgrounded) | local inference only runs foreground |

These fuse into `engagement ∈ [0,1]`: ~1.0 actively talking/looking, ~0.3 connected-but-idle, ~0.0 disconnected/backgrounded.

---

## Files

```
Sources/Services/Presence/
├── PresenceMonitor.swift   // fuses signals → @Published engagement: Double, @Published mode: EngagementMode
└── ThrottlePolicy.swift    // engagement → loop interval multiplier + autonomy level
```

- Touch: [LiveCoachService.swift](../../OpenGlasses/Sources/Services/LiveCoachService.swift) — derive the per-domain loop interval from `ThrottlePolicy` instead of a fixed cadence.
- Touch: ambient/assistive caption loop + `ProactiveAlertService` — same throttle source.
- Touch: [Plan S](S-plan-then-execute-and-safety-supervisor.md) `SafetySupervisor` — read `PresenceMonitor.mode`; when `idle`, force the `recommend` autonomy level (no auto-act).
- Touch: `Sources/App/OpenGlassesApp.swift` — construct `PresenceMonitor`, inject into the loops.

---

## Model

```swift
enum EngagementMode { case active, present, idle, away }   // away = disconnected/backgrounded

struct ThrottleDecision {
    let intervalMultiplier: Double   // 1.0 = base cadence; 4.0 = quarter as often; ∞ = paused
    let autonomy: Autonomy           // .autoAct | .recommend | .paused
}
```

`ThrottlePolicy.decide(engagement:mode:)` (pure function):

| Mode | engagement | interval × | autonomy |
|---|---|---|---|
| `active` | ~1.0 | 1.0 (full cadence) | autoAct (subject to Plan S supervisor) |
| `present` | ~0.5 | 2.0 | autoAct |
| `idle` (>5 min no engagement) | ~0.2 | 4.0 | **recommend** (surface, don't act) |
| `away` (disconnected/background) | 0.0 | paused | paused |

The autonomy downgrade is the safety half: an agent that hasn't seen the user engage in 5 minutes shouldn't *take* an action — it should hold it as a recommendation surfaced (spoken + HUD) when the user next engages. This composes with Plan S: the supervisor already gates high-impact actions; presence-`idle` simply lowers the global autonomy ceiling.

---

## Flow

```
PresenceMonitor (continuous, cheap)
   ├─ motion, voice activity, last-command age, connectivity, foreground
   ▼
engagement: Double  +  mode: EngagementMode   (@Published)
   ▼
loops read ThrottlePolicy.decide(...) each tick:
   • LiveCoach domain loop  → sleeps intervalMultiplier × base
   • ambient/proactive      → same
   • Plan S agent loop      → autonomy ceiling = decision.autonomy
   ▼
mode rises to .active (user speaks/looks) → loops resume full cadence;
held recommendations are spoken: "While you were idle: 2 suggestions."
```

---

## Build order

1. `PresenceMonitor` — start with the signals already on-device (voice-activity from the transcription pipeline + last-command timestamp + connectivity + foreground); add CoreMotion if not already present. `@Published engagement` + `mode`.
2. `ThrottlePolicy.decide` (pure) + tests (signal combos → expected decision).
3. Apply the multiplier in `LiveCoachService` loop first (most visible battery win) + tests.
4. Apply to ambient/proactive loops.
5. Wire `mode == .idle → recommend` into the Plan S supervisor's autonomy ceiling.
6. Held-recommendation surfacing on re-engagement (TTS + HUD).

---

## Tests
- `ThrottlePolicy` — each mode → expected interval multiplier + autonomy; boundary at the idle threshold.
- `PresenceMonitor` — synthetic signal streams → expected mode transitions (active→present→idle→away and back); debounced so a single missed tick doesn't flap.
- Loop integration — `LiveCoachService` interval scales with mode; resumes promptly on re-engagement.
- Safety — `idle` forces `recommend`; an auto-act request while idle is held, not executed.

---

## Open questions / decisions needed
- **Idle threshold:** 5 min before downgrade — too aggressive / too lax? *Recommendation: 5 min default, user-tunable in Settings; debounce 10–15 s to avoid flapping.*
- **CoreMotion permission:** worth the activity-type signal, or rely on voice + connectivity alone to avoid a new permission prompt? *Recommendation: ship v1 without CoreMotion (voice/connectivity/foreground are enough), add motion only if idle detection proves noisy.*
- **Does this override an explicit "stay alert" mode?** e.g. Navigation Assist should run hot regardless. *Recommendation: yes — loops can declare a `minMode` floor so safety-critical loops (hazard navigation) ignore the throttle.*
- **Battery vs latency:** throttling the loop adds latency to proactive surfacing. Acceptable when idle by definition. *Confirm no regression for active mode (multiplier 1.0).*

---

## Dependencies / prereqs
- [LiveCoachService.swift](../../OpenGlasses/Sources/Services/LiveCoachService.swift) (existing) — primary throttle consumer (per-domain loop).
- `ProactiveAlertService` + ambient/assistive loop (existing) — secondary consumers.
- Wake-word / transcription pipeline (existing) — the voice-activity signal source.
- DAT `DeviceSession` state (existing) — connectivity signal.
- **[Plan S](S-plan-then-execute-and-safety-supervisor.md)** — the autonomy-ceiling consumer; W is most valuable once S's agent loop exists, but the loop-throttle half ships value immediately on `LiveCoachService`.
- Note the Local Model Background memory: MLX inference is foreground-only, so `away`/backgrounded ⇒ paused is also a correctness constraint, not just an optimization.

---

## Why this matters specifically for you
An always-on agent on a face-worn, small-battery device shouldn't burn cycles — or take actions — when nobody's engaging. One cheap presence signal pays off twice: it extends battery by throttling the continuous loops you already run, and it makes autonomy *contextual* — the glasses act when you're in the loop and merely advise when you've wandered off. It's a small, self-contained service that makes every other loop (Live Coach today, the Plan S agent tomorrow) better-behaved.
