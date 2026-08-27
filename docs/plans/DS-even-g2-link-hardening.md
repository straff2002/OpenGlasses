# Plan DS — Even G2 Link Hardening and Display Fidelity

**Status:** 📝 Drafted (2026-08-27)
**Origin:** 2026-08-27 ecosystem review — protocol behaviors verified absent from our G2 backend,
each one a class of field failure that bench testing (foregrounded, both lenses healthy) never shows.
**Priority:** P1 (heartbeat) prevents silent background link death; P2 (wake word) prevents a
double-assistant misfire; the rest are correctness under load.

Our Even G2 backend ([EvenDisplayBackend.swift](../../OpenGlasses/Sources/Services/Display/Even/EvenDisplayBackend.swift),
[EvenBLETransport.swift](../../OpenGlasses/Sources/Services/Display/Even/EvenBLETransport.swift),
[EvenPacket.swift](../../OpenGlasses/Sources/Services/Display/Even/EvenPacket.swift),
[EvenScreenRenderer.swift](../../OpenGlasses/Sources/Services/Display/Even/EvenScreenRenderer.swift))
handles the essentials: dual left/right peripherals with single-lens degraded mode, `0xAA` framing,
CRC-16/CCITT-FALSE. What it lacks is everything that only shows up outside the happy path.

---

## Relevant seams

- `OpenGlasses/Sources/Services/Display/Even/*.swift` (all four files)
- `OpenGlasses/Sources/Services/GlassesDisplayService.swift` (backend-neutral queueing — unchanged,
  but the renderer contract in P4 feeds it)
- `OpenGlasses/Sources/Services/WakeWordService.swift` (P2 interaction: our wake word must be the
  only one listening)

## Decisions and invariants

1. **Heartbeat to BOTH lenses, cadence 10 s.** iOS's Bluetooth daemon reclaims a backgrounded BLE
   connection that has seen no traffic for ~50 s ("unused" teardown); with two independent
   peripherals, an idle *right* lens dies even while the left is chatty. The keep-alive is written
   per-peripheral, not per-device. Pure core: a `LinkKeepalivePolicy` that, given per-side
   last-traffic timestamps and app foreground state, emits which sides need a ping — testable
   without CoreBluetooth.
2. **Disable the glasses' onboard voice trigger during session setup.** The G2 firmware ships its
   own wake-word feature; if the backend never turns it off, the glasses' native assistant can fire
   alongside ours on every utterance. The handshake gains an explicit disable step, re-sent on
   reconnect (firmware state does not survive a link drop reliably). Setting restored (re-enabled)
   on clean backend teardown — we borrow the trigger, we don't confiscate it.
3. **Reassembly keys include the side.** Left and right lenses run independent sequence counters. Any
   multi-packet inbound reassembly keyed only by `(service, seq)` will interleave cross-side
   fragments into corrupt messages. Key by `(side, service, seq)`; drop a partial on any non-zero
   status byte.
4. **Acks resolve off the main actor.** An awaiting ack continuation stored behind `@MainActor`
   isolation adds an actor hop between the BLE callback and the waiter; under main-thread load the
   ack physically arrives but misses its timeout window, presenting as "glasses stopped responding".
   The ack box is a small `Sendable` class with its own lock, resolved directly on the
   CoreBluetooth queue.
5. **Text fit is measured, not assumed.** `EvenScreenRenderer.wrap` budgets a fixed character count
   per line; the G2 font is proportional, so `iiii` and `WWWW` get the same budget and wide lines
   clip. Replace with a character-width table (JSON resource, sums to pixel width against the panel's
   usable width) behind a `TextFitMeasuring` seam — the fixed budget stays as the fallback for
   unmapped characters.

## Phases

**P1 — Keepalive + reconnect resend (pure core + thin wiring).** `LinkKeepalivePolicy` with tests
(per-side independence, background cadence, suppression while real traffic flows); transport writes
the ping frame. Exit gate (manual, device): backgrounded app holds both links > 5 min.

**P2 — Handshake completeness.** Onboard-trigger disable/enable steps in session setup/teardown +
resend-on-reconnect. Pure `HandshakeScript` (ordered steps with per-step delays as data) so the
sequence is asserted in tests rather than encoded in control flow.

**P3 — Reassembly + ack correctness.** Side-keyed reassembler as a pure type with interleaved
cross-side fixture tests; non-isolated ack box with a race test (resolve-vs-timeout under contention).

**P4 — Measured text fit.** Width-table renderer behind `TextFitMeasuring`; fixture tests pin known
strings to known line breaks; `GlassesDisplayService` contract unchanged.

## Deferred (recorded, not planned)

- **Retained-mode scene diffing** (paint creates/updates first, sweep removals last, so a transition
  never blanks; an id reused with a different element type must be removed *before* repaint):
  worthwhile only when the HUD gains a second simultaneous producer class. Revisit with the display
  roadmap.
- **Display arbitration between competing producers** (exclusive background lock with inactivity
  auto-release + global throttle + boot-time queue/restore): same trigger — no third-party HUD
  surface exists today. `GlassesDisplayService`'s suppression rules cover current producers.
- **Capability modeling as behavior-protocol + parallel plain-data flags struct** per device model:
  fold into Plan CQ (third-party glasses backends) when its next phase is drafted, not here.
