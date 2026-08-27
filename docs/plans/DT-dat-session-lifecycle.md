# Plan DT — DAT Device-Session Lifecycle and State-as-Intent

**Status:** 📝 Drafted (2026-08-27)
**Origin:** 2026-08-27 ecosystem review + the device-session findings branch. Field-reported failure
classes in other DAT integrations that our seams don't yet defend against.
**Priority:** P1/P2 are bug-prevention on the pairing/permission path (the DAT permission gate is
already our known #1 blocker); P3 is a new interaction affordance, cheap once P1 exists.

`MetaCameraBackend` ([MetaCameraBackend.swift](../../OpenGlasses/Sources/Services/Camera/MetaCameraBackend.swift))
already awaits `.started`, prefers `SpecificDeviceSelector` for a mid-wake link, and does tiered
rebuilds (Plan BR). `DeviceSessionCoordinator`
([DeviceSessionCoordinator.swift](../../OpenGlasses/Sources/Services/Device/DeviceSessionCoordinator.swift), 90 lines)
creates one `AutoDeviceSelector` inside its factory closure and never watches the device list again.
Four lifecycle behaviors are missing; each maps to a documented field failure in DAT integrations.

---

## Relevant seams

- `OpenGlasses/Sources/Services/Device/DeviceSessionCoordinator.swift`
- `OpenGlasses/Sources/Services/Camera/MetaCameraBackend.swift`
- `OpenGlasses/Sources/Services/CameraErrorPolicy.swift` (already exhaustive on `StreamError` — unchanged)
- `OpenGlasses/Sources/Services/StreamRecoveryPolicy.swift` (`.paused` = temple-tap hold is already
  respected there; P3 turns that observation into intent)
- `OpenGlasses/Sources/Services/Triggers/AlternativeTrigger.swift` + Plan CH's `MediaTriggerService`
  (P3 lands as a sibling trigger source, same wake-path entry)

## Decisions and invariants

1. **The device list is watched for the process lifetime.** A selector created before a
   camera-permission grant (or before first pairing completes) can resolve no device and stays blind
   until rebuilt; symptom: "glasses paired, permission granted, app still says no device" until app
   restart. Keep one subscription to the SDK's devices stream from configure-time onward; when the
   selector is blind and the list becomes non-empty, rebuild it — with a re-entrancy guard and a
   cooldown so concurrent callers can't thrash.
2. **A transient nil active-device does not kill the session.** A BLE blip can momentarily report no
   active device. Teardown arms a grace timer (default 3 s) and re-checks before invalidating;
   a real doff/disconnect still tears down, just 3 s later — a blip costs nothing.
3. **A deliberate stop is not an error.** When *we* initiate stop (backgrounding, capability
   release, mode switch), stream-error events raced against that stop must not surface a user-facing
   failure. A bounded suppression window (15 s, generation-scoped) opens at deliberate-stop and
   closes on completion or timeout. Never suppress outside the window — real errors stay loud.
4. **Listener teardown is generation-guarded.** `ListenerTokenBag.cancelAll()` is async; a callback
   can land after cancel is requested but before it completes, acting on stale state. Every
   subscribe/resubscribe cycle bumps a generation counter; callbacks carrying a stale generation are
   dropped. Applies to camera state, stream error, and the new devices-stream subscriptions.
5. **Session state transitions are intent, not just telemetry (P3).** During an active session the
   temple gestures surface as state transitions: `running → paused` is the wearer's hold,
   `paused → running` their resume, and a stop whose proximate cause is doff/fold
   (`StreamError.hingesClosed` in 0.9.0) is the wearer *leaving*, not a fault. P3 maps these to:
   pause/resume = mute/unmute any live voice session; doff-stop = end the live session cleanly and
   say nothing (the wearer took the glasses off — a spoken error would land in their hand).
   This complements Plan CH, which owns the *out-of-session* tap via the media route; the two are
   arbitrated by session-activity (an active DAT session claims gesture meaning; CH stands down —
   CH's policy already defers to realtime sessions, so this is one more input to that table).

## Phases

**P1 — Selector vigilance (pure core + wiring).** `SelectorHealthPolicy` (device-list events +
selector blindness + cooldown → rebuild/no-op) with headless tests; wire the lifetime devices-stream
subscription and rebuild path into `DeviceSessionCoordinator`. Also verify at session start that at
least one active-device event has been observed before `createSession` (a session created against a
never-warmed selector throws no-eligible-device even with paired glasses).

**P2 — Teardown discipline.** Grace-period policy, deliberate-stop suppression window, and the
generation guard — all pure types with race-shaped tests (blip inside/outside grace; error inside/
outside window; stale-generation callback dropped). Wire into `MetaCameraBackend` teardown paths.

**P3 — State-as-intent.** `SessionGestureInterpreter` (pure): `(transition, cause, sessionActivity)`
→ `mute / unmute / endQuietly / ignore`, tested as a table. Wire as a trigger source beside CH's
media path; CH's claim table gains the "active DAT session owns the gesture" row. Device smoke
(which physical gestures produce which transitions on current firmware) deferred to the CH P3
protocol run — same session, same glasses.
