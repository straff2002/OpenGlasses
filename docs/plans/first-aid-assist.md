# Plan — First-Aid / Emergency Assist

**Status: 📋 Planned (not built).** Runs on the engines we already ship. Accessibility/Medical-tier,
life-safety.

**Strategic fit:** A hands-free **bystander first-aid coach** for the seconds that matter — paces CPR,
walks a responder through a structured emergency protocol, and routes them to the nearest defibrillator,
all eyes-up and hands-free. Sits in the **Accessibility / Medical Compliance** line and reuses the
remote-expert, navigation, HUD, and TTS engines already built. The brain dies after ~4 min without
oxygen; ambulances take ~8–20 min — this is the gap a hands-free coach fills.

**This is decision support, NOT a medical device** — every flow starts by confirming emergency services
were called and carries an "advisory only" disclaimer.

**Effort:** ~1 week (≈75% reuse; the metronome + protocol catalog + AED finder are the new pieces).

---

## Concept

Triggered by voice ("emergency" / "start CPR"), an alternative trigger, or a tool call, the glasses
enter a **First-Aid Assist mode** that:

- **Gate first:** "Have you called emergency services?" — the mode never starts a protocol before the
  responder confirms (or is prompted to) call 911/112.
- **CPR metronome** — an audible 100–120 bpm beat (TTS tone) paces compressions, with spoken coaching
  ("push hard and fast, centre of the chest") and **30:2 cycle tracking** (prompt 2 rescue breaths after
  30 compressions), spoken at high urgency.
- **Structured protocols** — a step-by-step runner for the highest-value bystander scenarios: **CPR/AED**,
  **choking** (back blows / Heimlich), **severe bleeding** (pressure / tourniquet), **recovery position**,
  and the **MARCH** trauma sequence. Hands-free advance (voice/"next").
- **AED finder + routing** — the nearest defibrillator via an OpenStreetMap **Overpass** query
  (`emergency=defibrillator`), spoken + an on-lens direction arrow + turn-by-turn (reuse Navigation Assist).
- **Optional remote responder** — escalate to a live POV + two-way audio session over the existing
  `ExpertBridge` transport.
- **HUD** — the current step, a compression-beat indicator, and the AED bearing on the lens.

---

## Files

```
Sources/Services/FirstAid/
├── FirstAidProtocol.swift        // catalog: CPR/AED, choking, bleeding, recovery, MARCH — structured steps
├── CPRMetronome.swift            // PURE bpm/beat/30:2-cycle/compression-count timing model (clock injected)
├── AEDFinder.swift               // Overpass query build + parse + nearest (haversine) + route hand-off
├── FirstAidAssistService.swift   // @MainActor: runs a protocol, drives the metronome + HUD + escalation
└── NativeTools/FirstAidTool.swift // first_aid: start <protocol> | next | aed | escalate | stop
Sources/App/Views/
└── FirstAidView.swift            // step + beat indicator + AED bearing (phone); mirrored to HUD
```

Reuse (no new infrastructure):
- **Protocol stepping** — [ProcedureRunner](../../OpenGlasses/Sources/Services/FieldAssist/ProcedureRunner.swift) shape (a first-aid protocol is a Procedure with terminal/branch steps).
- **Audio** — [TextToSpeechService](../../OpenGlasses/Sources/Services/TextToSpeechService.swift): the metronome reuses the in-memory tone generator (`generateToneData`); coaching uses `SpeechUrgency.high`.
- **Routing** — [NavigationAssistService](../../OpenGlasses/Sources/Services/Accessibility/NavigationAssistService.swift) + `LocationService` for the walk to the AED.
- **HUD** — [GlassesDisplayService](../../OpenGlasses/Sources/Services/GlassesDisplayService.swift): step card + AED bearing.
- **Escalation** — [ExpertBridge](../../OpenGlasses/Sources/Services/FieldAssist/ExpertBridge.swift) / `EscalationCoordinator` for a remote responder.
- **Trigger** — wake word, or the new `AlternativeTriggerService` (a deliberate shake to start CPR pacing hands-free).

---

## Deterministic core (the testable part)

```swift
/// Pure CPR pacing model — no audio, no timers. Given an injected clock it answers:
/// which beat are we on, is it time for a compression tone, and have we hit a 30:2 breath break.
struct CPRMetronome {
    var rate: Int = 110                 // bpm, clamped 100...120 (AHA guideline window)
    var compressionsPerCycle = 30
    var breathsPerCycle = 2
    private(set) var compressionCount = 0
    private(set) var cyclesCompleted = 0

    var beatInterval: TimeInterval { 60.0 / Double(min(max(rate, 100), 120)) }
    /// Advance to time `now`; returns the events to fire (a compression tone, or a "give 2 breaths" cue).
    mutating func tick(at now: TimeInterval) -> [Event] { /* … */ [] }
    enum Event: Equatable { case compression(count: Int), breathBreak(cycle: Int) }
}
```

- **`CPRMetronome`** — bpm → beat interval (clamped 100–120); compression counting; the **30:2 cycle**
  (after 30 compressions, emit a breath-break event); fully unit-testable with a synthetic clock.
- **`FirstAidProtocol`** — the catalog as structured step sequences; stable step ids; the "called
  emergency services?" gate is step 0 of every protocol.
- **`AEDFinder`** — Overpass query-URL construction (`node[emergency=defibrillator](around:R,lat,lon)`),
  fixture-JSON parse, **nearest by haversine**, empty-result handling — all pure; the live HTTP + on-lens
  route is device/network-gated.

---

## Tests (headless)

- **CPRMetronome**: 110 bpm → ~0.545 s interval; rate clamped to 100–120; 30 compressions → a `breathBreak`
  then the count resets and `cyclesCompleted` increments; compression count monotonic.
- **FirstAidProtocol**: catalog completeness (CPR/choking/bleeding/recovery/MARCH); every protocol's step 0
  is the call-emergency-services gate; stable step ids.
- **AEDFinder**: Overpass URL built for a given radius/coord; fixture → `[AED]`; nearest selected by
  haversine; empty list handled.
- **Disclaimer gating**: a protocol can't advance past step 0 until the emergency-services prompt is
  acknowledged.

---

## Deferred / risk

- **Liability is the dominant risk.** Advisory only, not a medical device, not a substitute for
  professional care. Every entry confirms 911/112 was called; every screen + the spoken intro carry the
  disclaimer; the assistant never claims it performed a real-world action.
- **On-device validation:** metronome timing precision (audio scheduling), real Overpass latency, on-lens
  route legibility — device-gated. The deterministic core (pacing model, protocol catalog, AED query/parse)
  is the headless gate.
- **Scope:** ship **CPR/AED + choking + severe bleeding** first (the highest-value bystander scenarios);
  MARCH/trauma and the remote-responder escalation are staged follow-ups (escalation reuses ExpertBridge).
- **No autonomy:** this is reactive guidance only — nothing here runs unprompted; not gated behind
  `agentModeEnabled` because it takes no autonomous action.

---

## Why this matters

It turns the glasses into a hands-free first-aid coach exactly when a bystander's hands are busy and
panic is high — pacing compressions, talking them through choking or bleeding control, and pointing them
at the nearest AED. It's a flagship **Accessibility/Medical** capability that reuses the remote-expert,
navigation, HUD, and TTS machinery already shipped, with a small, well-tested new core (the pacing model
+ protocol catalog + AED finder). High emotional + real-world impact; small new surface.
