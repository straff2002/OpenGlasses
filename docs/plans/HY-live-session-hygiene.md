# Plan HY: Live Session Hygiene (carry the conversation, stop when nobody is there, spend within a budget)

**Status:** 📝 Drafted 2026-10-10. Nothing built. Four small items, each its own PR with a pure
core: P0 mode-switch handover, P1 idle end, P2 Live Coach budget, P3 tools-off announcements. The
doff half of "end when nobody is there" is folded into Plan [CM](CM-dat-0-9-0-unlocks.md) P1 (see
Design 2).
**Origin:** The [October 2026 ecosystem review](../ecosystem-review-2026-10.md) (section 3 rows
"Mode switch forgets the conversation", "Live sessions never idle out", "Live Coach has no call
budget"; section 4 row "Tools-off realtime announcements"; Appendix B claim 5).
**Priority:** P1 and P2 are cost and battery defects: a forgotten realtime session streams to a
metered API for as long as the phone has power, and Live Coach can make 7,200 cloud calls in one
session. P0 is a conversation-quality fix the CF redial left half done. P3 is a one-line envelope
hardening.
**Surfaces:** `performModeSwitch`, the two realtime session managers, `LiveCoachService`,
`LiveInjection`. One new Config knob (idle minutes), no new UI beyond a Settings stepper.

Evidence paths under `OpenGlasses/Sources/`; line numbers as recorded by the review at `7a0cc0e0`,
re-read on `main` at `48bcae0c`.

---

## Why

1. **A mode switch keeps the frame pin and drops the words.** `performModeSwitch`
   (`App/OpenGlassesApp.swift:3080-3150`) runs Plan [CF](CF-mode-switch-redial.md)'s
   `ModeSwitchPolicy` and, on a redial, carries only the held frame pin (`:3096-3098`). The new
   session starts with no idea what was just said. The machinery to fix this exists and is unused
   here: `LiveContextHandover` (`Services/Live/LiveContextHandover.swift:59`) builds a bounded
   "recovered conversation" block from `LiveConversationRecorder` turns (six turns, 300 characters
   each), and both managers honour `pendingResumeContext`
   (`Services/GeminiLive/GeminiLiveSessionManager.swift:75`). It is written only by the offline
   handoff (`App/AppState+OfflineHandoff.swift:72-73`).
2. **Live sessions never idle out.** There is no inactivity timer anywhere in
   `Services/GeminiLive/`, `Services/OpenAIRealtime/` or `Services/Live/`. A session started and
   forgotten keeps the microphone, the camera at its live interval and a billed socket open.
   Plan [W](W-presence-aware-agent-throttle.md) throttles frames when the wearer is away; it does
   not end anything. CM P1's `WearStatePolicy` fan-out, which would end things on doff, is unbuilt
   and its consumer list omits live sessions (`docs/plans/README.md`, CM row).
3. **Live Coach has no budget.** `LiveCoachService.start` clamps the interval to 1 to 10 s and the
   duration to 120 minutes (`Services/LiveCoachService.swift:107-109`): up to 7,200 cloud vision
   calls in one session, each sent whether or not the view changed.
4. **Announcements can start tool calls.** Deferred results and agent completions are injected
   into an OpenAI Realtime session followed by a bare `response.create`
   (`Services/Live/LiveInjection.swift:88`), so the model may answer an announcement by calling
   another tool, which can chain.

## Scope

**In:** handover on mode switch; an idle end with a spoken warning; a live-session row in CM P1's
wear table; a rolling call budget and a change gate for Live Coach; `tool_choice: none` on
announcement turns.

**Non-goals:**
- Persisting conversations across launches. The handover stays in memory, as the offline handoff
  is today.
- Ending user-started recordings or broadcasts on idle. Those have their own owners (DR, CY).
- A budget for the navigation loop. Plan J's hazard loop is safety work and is never budgeted;
  its own staleness fix is in Plan [ID](ID-ecosystem-review-hardening-bundle.md).
- Gemini Live tools-off. Its protocol has no per-turn tool switch; P3 says so in a comment and a
  test, and leaves Gemini alone.

## Design

### 1 · Handover on mode switch (P0)

A pure `ModeSwitchHandover.seed(from:to:actions:oldRecorderTurns:directTurns:now:)` returns the
block to set, or nil:

| Switch | Source | When |
|---|---|---|
| live → live with `.startSession` (the CF redial) | the old manager's `LiveConversationRecorder.turns` | always |
| Direct → live (no redial: the policy never starts a session from Direct) | the Direct thread's last six turns | only if the newest is under 10 minutes old; set as `pendingResumeContext` and consumed by the next start |
| anything → Direct | none (open question 1) | |

`performModeSwitch` reads the source **before** the teardown action runs (the recorder is cleared
by `stopSession`), calls `LiveContextHandover.build`, and sets it on the target manager before
`.startSession`. A pending seed is cleared by any later mode switch, so a stale block cannot ride
into an unrelated session. In memory only.

### 2 · Ending a live session nobody is using (P1, plus a CM P1 row)

**Idle, here.** Pure `LiveIdlePolicy`:

```swift
struct LiveIdlePolicy {
    var idleLimit: TimeInterval = 600      // Config.liveIdleMinutes, default 10
    var warningLead: TimeInterval = 30
    enum Decision: Equatable { case none, warn, end }
    func decide(lastActivity: Date, warned: Bool, now: Date) -> Decision
}
```

Activity is wearer speech (input transcription or a VAD speech-start), a tool call or result,
a typed message, and a touch on the live controls. Model speech is not activity: a session
talking to an empty room is exactly the case. At `warn` the session speaks one line, "I'll end
this session in 30 seconds unless you say something", through the session's own audio path; any
activity resets. At `end` the manager calls `stopSession()` with an `idleEnded` reason, logged and
shown on the status card as "Session ended after 10 minutes without activity". Both managers own
one small `LiveIdleClock` that feeds the policy on a 5 s tick.

**Doff, in CM P1.** Rather than a second wear policy, CM P1's unbuilt `WearStatePolicy` gains a
consumer row: an active Gemini Live or OpenAI Realtime session **ends** after 60 s doffed (no
resume on re-don: a new session is one tap or phrase away, and a resumed socket would bill the
gap). CM's amendment of 2026-10-10 records the row and points here. The wear signal should be
`GlassesConnectionService.isWorn` (the stable `donState`, mapped since the 1.0.0 work) with
`StreamError.hingesClosed` as a fallback, since `isWorn` did not exist when CM was drafted. The
idle half here ships first and does not wait for CM.

### 3 · Live Coach budget and change gate (P2)

- Pure `CallBudget`: a rolling one-hour window (default 240 calls, about one every 15 s on
  average), `admit(now:) -> Bool`, `remaining(now:)`. Injected clock.
- `LiveCoachService` runs each tick's frame through a `FrameGate` (the AT gate,
  `Services/Vision/FrameGate.swift:16`) with a heartbeat of 30 s, so an unchanged view is not
  re-sent more often than the heartbeat; only a frame the gate forwards spends from the budget.
- When the budget is spent the coach says once, "I've given a lot of advice this hour; I'll check
  in less often", and the effective interval stretches until the window frees calls. It never
  stops silently and never runs past `maxDuration`.
- Navigation (`NavigationAssistService`) and first-aid loops never take a `CallBudget`; a test
  scans that neither file references it.

### 4 · Tools-off announcements (P3)

`LiveInjection.realtimeResponseCreate(toolsAllowed: Bool = true)`. With `false` it emits
`{"type": "response.create", "response": {"tool_choice": "none"}}`. Every announcement path
(deferred tool results, agent completions, notifications read aloud) passes `false`; a wearer turn
never goes through this function. Gemini Live: a comment at the injection site and a test that
the Gemini envelope is unchanged.

## Phases

- **P0 (one PR):** `ModeSwitchHandover` + wiring. **Tests:** `ModeSwitchHandoverTests` (each row of
  the table; a Direct seed older than 10 minutes is dropped; a later switch clears a pending seed;
  the block is `LiveContextHandover`'s, with its heading); `ModeSwitchPolicyTests` unchanged.
- **P1 (one PR):** `LiveIdlePolicy`, `LiveIdleClock` in both managers, `Config.liveIdleMinutes`
  (Settings stepper under live conversation settings, 5 to 60 minutes, or Off), the warning line,
  the status-card reason. **Tests:** `LiveIdlePolicyTests` (warn at limit minus lead, end at
  limit, activity resets, model speech does not count, warning said once); a manager-level test
  through the existing fake socket seams that `stopSession` is called with `idleEnded`.
- **P2 (one PR):** `CallBudget`, the gate in `LiveCoachService`, the spent line. **Tests:**
  `CallBudgetTests` (window roll-off, exact boundary, injected clock); `LiveCoachTests` gains
  "unchanged view is not re-sent before the heartbeat" and "budget spent is said once"; the
  navigation-exemption source scan.
- **P3 (one PR, XS):** the `toolsAllowed` flag. **Tests:** `LiveInjectionTests` envelope cases
  (default unchanged; `false` carries `tool_choice: none`; Gemini envelope untouched).

**Gates (each):** full suite and Release build green, `SWIFT_EMIT_LOC_STRINGS=NO`, privacy-logging
gate; this Status line and the index row updated in the same PR.

**Device pass (owed after P1):** leave a Gemini Live session running on the desk for 11 minutes
and hear the warning and the end; confirm the socket closes and the camera stops.

## Open questions

1. Should a live → Direct switch seed the Direct thread with the live turns? Recommended: not in
   this plan; Direct already keeps its own thread, and mixing transcripts needs a decision about
   what the Direct history means.
2. Default idle limit: 10 minutes (recommended) or shorter on a metered key? A per-provider
   default is possible later.
3. Live Coach default budget: 240 an hour is a proposal; the cost tracker (Plan AU) can show
   whether it bites.

## Dependencies

- **CF** (✅ P1 shipped): the redial this extends.
- **CM** P1 (🚧, the `WearStatePolicy` fan-out unbuilt; index and file agree): owns the doff end,
  amended 2026-10-10.
- **AT** (🚧 core shipped): the `FrameGate` P2 reuses.
- **W** (✅): presence throttling stays; this plan ends sessions, W slows them.
- **BD** and **FF**: the reconnect and handover paths `pendingResumeContext` already serves.
